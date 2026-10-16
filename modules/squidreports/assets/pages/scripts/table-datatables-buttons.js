var TableDatatablesButtons = function () {

    var initTable3 = function () {
        var table = $('#sample_3');
        if (!table.length) return;

        var oTable = table.dataTable({

            "language": {
                "aria": {
                    "sortAscending": ": activate to sort column ascending",
                    "sortDescending": ": activate to sort column descending"
                },
                "emptyTable": "No data available in table",
                "info": "Showing _START_ to _END_ of _TOTAL_ entries",
                "infoEmpty": "No entries found",
                "infoFiltered": "(filtered from _MAX_ total entries)",
                "lengthMenu": "_MENU_ entries",
                "search": "Search:",
                "zeroRecords": "No matching records found"
            },

            buttons: [
                { extend: 'copy', className: 'btn red btn-outline' },
                { 
                    extend: 'pdf', 
                    className: 'btn green btn-outline',
                    exportOptions: {
                        modifier: {
                            search: 'none',
                            order: 'current',
                            page: 'all'
                        }
                    },
                    orientation: 'landscape',
                    pageSize: 'A4',
                    filename: 'reporte_detalles.pdf',
                    customize: function (doc) {
                        doc.content[1].table.widths = doc.content[1].table.body[0].map(function () { return '*'; });
                        doc.defaultStyle.fontSize = 8;
                    }
                },
                { 
                    extend: 'excel', 
                    className: 'btn yellow btn-outline ',
                    filename: 'reporte_detalles.xlsx'
                },
                { 
                    extend: 'csv', 
                    className: 'btn purple btn-outline ',
                    filename: 'reporte_detalles.csv'
                },
                { extend: 'colvis', className: 'btn dark btn-outline', text: 'Columns'}
            ],

            responsive: false,
            "order": [[0, 'desc']],
            
            "lengthMenu": [
                [5, 10, 15, 20, -1],
                [5, 10, 15, 20, "All"]
            ],
            "pageLength": 10
        });

        $('#sample_3_tools > li > a.tool-action').on('click', function() {
            var action = $(this).attr('data-action');
            oTable.DataTable().button(action).trigger();
        });
    }
	
	var initTable4 = function () {
        var table = $('#metro_tpl_2');
        if (!table.length) return;

        var oTable = table.dataTable({

            "language": {
                "aria": {
                    "sortAscending": ": activate to sort column ascending",
                    "sortDescending": ": activate to sort column descending"
                },
                "emptyTable": "No data available in table",
                "info": "Showing _START_ to _END_ of _TOTAL_ entries",
                "infoEmpty": "No entries found",
                "infoFiltered": "(filtered from _MAX_ total entries)",
                "lengthMenu": "_MENU_ entries",
                "search": "Search:",
                "zeroRecords": "No matching records found"
            },

            buttons: [
                { extend: 'copy', className: 'btn red btn-outline' },
                { 
                    extend: 'pdf', 
                    className: 'btn green btn-outline',
                    exportOptions: {
                        modifier: {
                            search: 'none',
                            order: 'current',
                            page: 'all'
                        }
                    },
                    orientation: 'landscape',
                    pageSize: 'A4',
                    filename: 'reporte_metro.pdf',
                    customize: function (doc) {
                        doc.content[1].table.widths = ['5%', '20%', '20%', '15%', '15%', '10%', '8%', '7%'];
                        if (doc.content[1].table.body[0].length > doc.content[1].table.widths.length) {
                            doc.content[1].table.widths = doc.content[1].table.body[0].map(function () { return '*'; });
                        }
                        doc.defaultStyle.fontSize = 8;
                    }
                },
                { 
                    extend: 'excel', 
                    className: 'btn yellow btn-outline ',
                    filename: 'reporte_metro.xlsx'
                },
                { 
                    extend: 'csv', 
                    className: 'btn purple btn-outline ',
                    filename: 'reporte_metro.csv'
                },
                { extend: 'colvis', className: 'btn dark btn-outline', text: 'Columns'}
            ],

            responsive: false,
            "order": [[0, 'asc']],
            
            "lengthMenu": [
                [5, 10, 15, 20, -1],
                [5, 10, 15, 20, "All"]
            ],
            "pageLength": 10
        });

        $('#sample_3_tools > li > a.tool-action').on('click', function() {
            var action = $(this).attr('data-action');
            oTable.DataTable().button(action).trigger();
        });
    }

	var initTable5 = function () {
        var table = $('#metro_tpl_3');
        if (!table.length) return;

        var oTable = table.dataTable({

            "language": {
                "aria": {
                    "sortAscending": ": activate to sort column ascending",
                    "sortDescending": ": activate to sort column descending"
                },
                "emptyTable": "No data available in table",
                "info": "Showing _START_ to _END_ of _TOTAL_ entries",
                "infoEmpty": "No entries found",
                "infoFiltered": "(filtered from _MAX_ total entries)",
                "lengthMenu": "_MENU_ entries",
                "search": "Search:",
                "zeroRecords": "No matching records found"
            },

            buttons: [
                { extend: 'copy', className: 'btn red btn-outline' },
                { 
                    extend: 'pdf', 
                    className: 'btn green btn-outline',
                    exportOptions: {
                        modifier: {
                            search: 'none',
                            order: 'current',
                            page: 'all'
                        }
                    },
                    orientation: 'landscape',
                    pageSize: 'A4',
                    filename: 'reporte_metro_3.pdf'
                },
                { 
                    extend: 'excel', 
                    className: 'btn yellow btn-outline ',
                    filename: 'reporte_metro_3.xlsx'
                },
                { 
                    extend: 'csv', 
                    className: 'btn purple btn-outline ',
                    filename: 'reporte_metro_3.csv'
                },
                { extend: 'colvis', className: 'btn dark btn-outline', text: 'Columns'}
            ],

            responsive: false,
            "order": false,
            
            "lengthMenu": [
                [5, 10, 15, 20, -1],
                [5, 10, 15, 20, "All"]
            ],
            "pageLength": 10
        });

        $('#metro_tpl_3_tools > li > a.tool-action').on('click', function() {
            var action = $(this).attr('data-action');
            oTable.DataTable().button(action).trigger();
        });
    }

    return {

        init: function () {

            if (!jQuery().dataTable) {
                return;
            }

            initTable3();
			initTable4();
			initTable5();
        }

    };

}();

jQuery(document).ready(function() {
    TableDatatablesButtons.init();
});
